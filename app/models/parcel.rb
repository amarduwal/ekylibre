# = Informations
#
# == License
#
# Ekylibre - Simple agricultural ERP
# Copyright (C) 2008-2009 Brice Texier, Thibaud Merigon
# Copyright (C) 2010-2012 Brice Texier
# Copyright (C) 2012-2017 Brice Texier, David Joulin
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see http://www.gnu.org/licenses.
#
# == Table: parcels
#
#  accounted_at                         :datetime
#  address_id                           :integer
#  contract_id                          :integer
#  created_at                           :datetime         not null
#  creator_id                           :integer
#  currency                             :string
#  custom_fields                        :jsonb
#  delivery_id                          :integer
#  delivery_mode                        :string
#  given_at                             :datetime
#  id                                   :integer          not null, primary key
#  in_preparation_at                    :datetime
#  intervention_id                      :integer
#  journal_entry_id                     :integer
#  late_delivery                        :boolean
#  lock_version                         :integer          default(0), not null
#  nature                               :string           not null
#  number                               :string           not null
#  ordered_at                           :datetime
#  planned_at                           :datetime         not null
#  position                             :integer
#  prepared_at                          :datetime
#  pretax_amount                        :decimal(19, 4)   default(0.0), not null
#  purchase_id                          :integer
#  recipient_id                         :integer
#  reconciliation_state                 :string
#  reference_number                     :string
#  remain_owner                         :boolean          default(FALSE), not null
#  responsible_id                       :integer
#  sale_id                              :integer
#  sender_id                            :integer
#  separated_stock                      :boolean
#  state                                :string           not null
#  storage_id                           :integer
#  transporter_id                       :integer
#  type                                 :string
#  undelivered_invoice_journal_entry_id :integer
#  updated_at                           :datetime         not null
#  updater_id                           :integer
#  with_delivery                        :boolean          default(FALSE), not null
#

class Parcel < Ekylibre::Record::Base
  include Attachable
  include Customizable
  attr_readonly :currency
  refers_to :currency
  enumerize :nature, in: %i[incoming outgoing], predicates: true, scope: true, default: :incoming
  enumerize :delivery_mode, in: %i[transporter us third], predicates: { prefix: true }, scope: true, default: :us
  enumerize :reconciliation_state, in: %i[to_reconcile reconcile], default: :to_reconcile
  belongs_to :address, class_name: 'EntityAddress'
  belongs_to :delivery
  belongs_to :journal_entry, dependent: :destroy
  belongs_to :undelivered_invoice_journal_entry, class_name: 'JournalEntry', dependent: :destroy
  belongs_to :storage, class_name: 'Product'
  belongs_to :responsible, class_name: 'User'
  belongs_to :transporter, class_name: 'Entity'
  belongs_to :contract
  has_many :items, class_name: 'ParcelItem', inverse_of: :parcel, foreign_key: :parcel_id, dependent: :destroy
  has_many :products, through: :items
  has_many :issues, as: :target
  # has_many :interventions, class_name: 'Intervention', as: :resource

  # [VALIDATORS[ Do not edit these lines directly. Use `rake clean:validations`.
  validates :accounted_at, :given_at, :in_preparation_at, :ordered_at, :prepared_at, timeliness: { on_or_after: -> { Time.new(1, 1, 1).in_time_zone }, on_or_before: -> { Time.zone.now + 50.years } }, allow_blank: true
  validates :late_delivery, :separated_stock, inclusion: { in: [true, false] }, allow_blank: true
  validates :nature, presence: true
  validates :number, presence: true, uniqueness: true, length: { maximum: 500 }
  validates :planned_at, presence: true, timeliness: { on_or_after: -> { Time.new(1, 1, 1).in_time_zone }, on_or_before: -> { Time.zone.now + 50.years } }
  validates :pretax_amount, presence: true, numericality: { greater_than: -1_000_000_000_000_000, less_than: 1_000_000_000_000_000 }
  validates :reference_number, length: { maximum: 500 }, allow_blank: true
  validates :remain_owner, :with_delivery, inclusion: { in: [true, false] }
  validates :state, presence: true, length: { maximum: 500 }
  # ]VALIDATORS]
  validates :delivery_mode, :address, presence: true
  validates :transporter, presence: { if: :delivery_mode_transporter? }

  scope :without_transporter, -> { with_delivery_mode(:transporter).where(transporter_id: nil) }
  scope :with_delivery, -> { where(with_delivery: true) }
  scope :to_deliver, -> { with_delivery.where(delivery_id: nil).where.not(state: :given) }

  accepts_nested_attributes_for :items, reject_if: :all_blank, allow_destroy: true

  acts_as_list scope: :delivery
  acts_as_numbered
  delegate :draft?, :ordered?, :in_preparation?, :prepared?, :started?, :finished?, to: :delivery, prefix: true

  before_validation do
    self.planned_at ||= Time.zone.today
    self.currency ||= Preference[:currency]
    self.pretax_amount = items.sum(:pretax_amount)
  end

  validate do
    if delivery && delivery.transporter && transporter
      if delivery.transporter != transporter
        errors.add :transporter_id, :invalid
      end
    end
  end

  before_update do
    if given_at != old_record.given_at
      products.each do |product|
        product.readings.where(read_at: old_record.given_at).update_all(read_at: given_at)
      end
    end
  end

  protect on: :destroy do
    prepared? || given?
  end

  def printed_at
    given_at || created_at || Time.zone.now
  end

  def printed_on
    printed_at.to_date
  end

  def content_sentence
    sentence = items.map(&:name).compact.to_sentence
  end

  def separated_stock?
    separated_stock
  end

  def invoiced?
    purchase.present? || sale.present?
  end

  def invoiceable?
    !invoiced?
  end

  def delivery?
    delivery.present?
  end

  def delivery_started?
    delivery?
  end

  def shippable?
    with_delivery && delivery.blank?
  end

  def allow_items_update?
    !prepared? && !given?
  end

  def address_coordinate
    address.coordinate if address
  end

  def address_mail_coordinate
    (address || sale.client.default_mail_address).mail_coordinate
  end

  def human_delivery_mode
    delivery_mode.text
  end

  def human_delivery_nature
    nature.text
  end

  def nature
    ActiveSupport::Deprecation.warn('Parcel#nature is deprecated, please use Parcel#type instead. This method will be removed in next major release 3.0')
    super
  end

  def nature=(value)
    ActiveSupport::Deprecation.warn('Parcel#nature= is deprecated, please use STI instead. This method will be removed in next major release 3.0')
    super(value)
  end

  # Number of products delivered
  def items_quantity
    items.sum(:population)
  end

  def all_items_prepared?
    any_items? && items.all?(&:prepared?)
  end

  def any_items?
    items.any?
  end

  def issues?
    issues.any?
  end

  def giveable?
    !with_delivery || (with_delivery && delivery.present? && delivery.started?)
  end

  def status
    if given?
      (issues? ? :caution : :go)
    else
      (issues? ? :stop : :caution)
    end
  end

  def first_available_date
    given_at || planned_at || prepared_at || in_preparation_at || ordered_at
  end

  class << self
    # Ships parcels. Returns a delivery
    # options:
    #   - deliver<y_mode: delivery mode
    #   - transporter_id: the transporter ID if delivery mode is :transporter
    #   - responsible_id: the responsible (Entity) ID for the delivery
    # raises:
    #   - "Need an obvious transporter to ship parcels" if there is no unique transporter for the parcels
    def ship(parcels, options = {})
      delivery = nil
      transaction do
        if options[:transporter_id]
          options[:delivery_mode] ||= :transporter
        elsif !delivery_mode.values.include? options[:delivery_mode].to_s
          raise "Need a valid delivery mode at least if no transporter given. Got: #{options[:delivery_mode].inspect}. Expecting one of: #{delivery_mode.values.map(&:inspect).to_sentence}"
        end
        delivery_mode = options[:delivery_mode].to_sym
        if delivery_mode == :transporter
          unless options[:transporter_id] && Entity.find_by(id: options[:transporter_id])
            transporter_ids = transporters_of(parcels).uniq
            if transporter_ids.size == 1
              options[:transporter_id] = transporter_ids.first
            else
              raise StandardError, 'Need an obvious transporter to ship parcels'
            end
          end
        end
        options[:started_at] ||= Time.zone.now
        options[:mode] = options.delete(:delivery_mode)
        delivery = Delivery.create!(options.slice!(:started_at, :transporter_id, :mode, :responsible_id, :driver_id))
        parcels.each do |parcel|
          parcel.delivery_mode = delivery_mode
          parcel.transporter_id = options[:transporter_id]
          parcel.delivery = delivery
          parcel.save!
        end
        delivery.save!
      end
      delivery
    end

    # Returns an array of all the transporter ids for the given parcels
    def transporters_of(parcels)
      parcels.map(&:transporter_id).compact
    end

    # Convert parcels to one sale. Assume that all parcels are checked before.
    # Sale is written in DB with default values
    def convert_to_sale(parcels)
      sale = nil
      transaction do
        parcels = parcels.collect do |d|
          (d.is_a?(self) ? d : find(d))
        end.sort_by(&:first_available_date)
        third = detect_third(parcels)
        planned_at = parcels.last.first_available_date || Time.zone.now
        unless nature = SaleNature.by_default
          unless journal = Journal.sales.opened_on(planned_at).first
            raise 'No sale journal'
          end
          nature = SaleNature.create!(
            active: true,
            currency: Preference[:currency],
            with_accounting: true,
            journal: journal,
            by_default: true,
            name: SaleNature.tc('default.name', default: SaleNature.model_name.human)
          )
        end
        sale = Sale.create!(
          client: third,
          nature: nature,
          # created_at: planned_at,
          delivery_address: parcels.last.address
        )

        # Adds items
        parcels.each do |parcel|
          parcel.items.each do |item|
            # raise "#{item.variant.name} cannot be sold" unless item.variant.saleable?
            next unless item.variant.saleable? && item.population && item.population > 0
            catalog_item = Catalog.by_default!(:sale).items.find_by(variant: item.variant)
            item.sale_item = sale.items.create!(
              variant: item.variant,
              unit_pretax_amount: (catalog_item ? catalog_item.amount : 0.0),
              tax: item.variant.category.sale_taxes.first || Tax.first,
              quantity: item.population
            )
            item.save!
          end
          parcel.reload
          parcel.sale_id = sale.id
          parcel.save!
        end

        # Refreshes affair
        sale.save!
      end
      sale
    end

    # Convert parcels to one purchase. Assume that all parcels are checked before.
    # Purchase is written in DB with default values
    def convert_to_purchase(parcels)
      purchase = nil
      transaction do
        parcels = parcels.collect do |d|
          (d.is_a?(self) ? d : find(d))
        end.sort_by(&:first_available_date)
        third = detect_third(parcels)
        planned_at = parcels.last.first_available_date || Time.zone.now
        unless nature = PurchaseNature.by_default
          unless journal = Journal.purchases.opened_on(planned_at).first
            raise 'No purchase journal'
          end
          nature = PurchaseNature.create!(
            active: true,
            currency: Preference[:currency],
            with_accounting: true,
            journal: journal,
            by_default: true,
            name: PurchaseNature.tc('default.name', default: PurchaseNature.model_name.human)
          )
        end
        purchase = Purchase.create!(
          supplier: third,
          nature: nature,
          planned_at: planned_at,
          delivery_address: parcels.last.address
        )

        # Adds items
        parcels.each do |parcel|
          parcel.items.each do |item|
            next unless item.variant.purchasable? && item.population && item.population > 0
            catalog_item = Catalog.by_default!(:purchase).items.find_by(variant: item.variant)
            item.purchase_item = purchase.items.create!(
              variant: item.variant,
              unit_pretax_amount: (item.unit_pretax_amount.nil? || item.unit_pretax_amount.zero? ? (catalog_item ? catalog_item.amount : 0.0) : item.unit_pretax_amount),
              tax: item.variant.category.purchase_taxes.first || Tax.first,
              quantity: item.population
            )
            item.save!
          end
          parcel.reload
          parcel.purchase = purchase
          parcel.save!
        end

        # Refreshes affair
        purchase.save!
      end
      purchase
    end

    def detect_third(parcels)
      thirds = parcels.map(&:third_id).uniq
      raise "Need unique third (#{thirds.inspect})" if thirds.count != 1
      Entity.find(thirds.first)
    end
  end
end
